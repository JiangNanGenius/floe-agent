// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.policy

import java.util.Locale

/**
 * Syntactic scope and path policy used by both the App client and the
 * privileged service. It never resolves symlinks by itself; the service also
 * canonicalizes and re-checks after resolution, so a link inside a granted root
 * that points outside is refused there.
 *
 * Scope bases are explicit host capability limits, not a blanket ban on every
 * privileged path: a bounded grant may name shared storage, another app's
 * package directory or a read-only platform tree. Kernel, credential and
 * Floe-private trees remain hard-denied, and this object never remounts or
 * changes platform security.
 */
object PathPolicy {

    const val MAX_RELATIVE_PATH = 512
    const val MAX_SEGMENTS = 32
    const val MAX_SEGMENT = 255

    private val SYSTEM_ROOT_NAMES = setOf("system", "vendor", "product", "system_ext", "odm", "apex")
    private val ANDROID_APP_DIRS = setOf("data", "media", "obb")

    sealed interface RelativeResult {
        data class Ok(val relative: String) : RelativeResult
        data class Rejected(val code: String) : RelativeResult
    }

    fun normalizeRelative(raw: String): RelativeResult {
        if (raw.length > MAX_RELATIVE_PATH) return RelativeResult.Rejected("path_length")
        if (raw.any { it == '\u0000' || it.isISOControl() }) return RelativeResult.Rejected("path_chars")
        if (raw.startsWith("/")) return RelativeResult.Rejected("absolute")
        if (raw.contains('\\')) return RelativeResult.Rejected("separator")
        if (raw.isEmpty()) return RelativeResult.Ok("")
        val segments = raw.split('/')
        if (segments.size > MAX_SEGMENTS) return RelativeResult.Rejected("depth")
        val normalized = ArrayList<String>(segments.size)
        for (segment in segments) {
            if (segment.isEmpty() || segment == ".") continue
            if (segment == "..") return RelativeResult.Rejected("traversal")
            if (segment.length > MAX_SEGMENT) return RelativeResult.Rejected("segment")
            if (segment.any { it == '\u0000' }) return RelativeResult.Rejected("path_chars")
            normalized.add(segment)
        }
        if (normalized.isEmpty()) return RelativeResult.Ok("")
        val result = normalized.joinToString("/")
        if (result.length > MAX_RELATIVE_PATH) return RelativeResult.Rejected("path_length")
        return RelativeResult.Ok(result)
    }

    /** Lexical containment check over already-normalized absolute paths. */
    fun isWithin(canonicalRoot: String, candidate: String): Boolean {
        if (canonicalRoot == "/") return candidate.startsWith("/")
        return candidate == canonicalRoot || candidate.startsWith(canonicalRoot.trimEnd('/') + "/")
    }

    fun isWithinAny(canonicalRoots: List<String>, candidate: String): Boolean =
        canonicalRoots.any { isWithin(it, candidate) }

    /**
     * Validates one host-approved scope base.
     *
     * @param writable true when the host intends to mutate this scope. The
     *   platform trees `/system`, `/vendor`, `/product`, `/system_ext`, `/odm`
     *   and `/apex` are inspection-only for this batch, so a writable grant for
     *   them is rejected; no code remounts or changes platform security.
     */
    fun validateScopeBase(
        path: String,
        floePackages: Set<String>,
        writable: Boolean = false,
    ): String? {
        if (!path.startsWith("/")) return "scope_relative"
        if (path.length > 1024) return "scope_length"
        if (path.any { it == '\u0000' || it.isISOControl() }) return "scope_chars"
        val normalized = normalizeBase(path) ?: return "scope_syntax"
        if (normalized == "/") return "scope_root"
        if (isFloePrivatePath(normalized, floePackages)) return "scope_floe_private"
        if (isHardForbiddenPath(normalized)) return "scope_forbidden"
        if (isBroadParent(normalized)) return "scope_forbidden"
        if (isReadOnlySystemPath(normalized)) {
            return if (writable) "scope_read_only" else null
        }
        if (isSharedStorageScope(normalized)) return null
        if (isOtherAppDataScope(normalized, floePackages)) return null
        if (isAdoptedAppDataScope(normalized, floePackages)) return null
        if (normalized == "/data/local/tmp" || normalized.startsWith("/data/local/tmp/")) return null
        return "scope_forbidden"
    }

    fun normalizeBase(path: String): String? {
        if (path.isEmpty() || path[0] != '/') return null
        if (path.any { it == '\u0000' || it.isISOControl() }) return null
        val segments = path.split('/').filter { it.isNotEmpty() && it != "." }
        if (segments.any { it == ".." || it.length > MAX_SEGMENT }) return null
        return "/" + segments.joinToString("/")
    }

    fun displayName(relative: String): String {
        if (relative.isEmpty()) return ""
        return relative.substringAfterLast('/')
    }

    fun lowerExtension(relative: String): String {
        val name = displayName(relative)
        val dot = name.lastIndexOf('.')
        if (dot <= 0 || dot == name.length - 1) return ""
        return name.substring(dot + 1).lowercase(Locale.ROOT)
    }

    /**
     * True when [path] is a Floe-private data or app-specific external
     * directory for any user, direct-boot alias, `/data/data` alias or adopted
     * volume alias. A root/ancestor grant must never open these children.
     */
    fun isFloePrivatePath(path: String, floePackages: Set<String>): Boolean {
        val normalized = normalizeBase(path) ?: return true
        if (floePackages.isEmpty()) return true
        // Expand the stable Floe parent here as well, so a caller that
        // supplies only its own package still protects the sibling runtime
        // package. Already-resolved sets are unchanged by the resolver.
        val protectedPackages = FloePackageFamily.protectedPackages(floePackages)
        val segments = pathSegments(normalized)
        for (i in segments.indices) {
            if (segments[i] == "Android" && i + 2 < segments.size &&
                segments[i + 1] in ANDROID_APP_DIRS &&
                isFloePackage(segments[i + 2], protectedPackages)
            ) {
                return true
            }
        }
        val pkg = when {
            segments.size >= 3 && segments[0] == "data" && segments[1] == "data" ->
                segments[2]
            segments.size >= 4 && segments[0] == "data" &&
                (segments[1] == "user" || segments[1] == "user_de") &&
                isUserSegment(segments[2]) -> segments[3]
            segments.size >= 6 && segments[0] == "mnt" && segments[1] == "expand" &&
                isVolumeId(segments[2]) &&
                (segments[3] == "user" || segments[3] == "user_de") &&
                isUserSegment(segments[4]) -> segments[5]
            segments.size >= 5 && segments[0] == "mnt" && segments[1] == "expand" &&
                isVolumeId(segments[2]) && segments[3] == "app" -> segments[4]
            else -> null
        }
        return pkg != null && isFloePackage(pkg, protectedPackages)
    }

    /**
     * True when [path] is an ancestor of a Floe-private tree. Recursive delete
     * must refuse such a target before mutating anything, including a shared
     * storage root that contains `/Android/data/<floe package>`.
     */
    fun isFloePrivateAncestor(path: String, floePackages: Set<String>): Boolean {
        val normalized = normalizeBase(path) ?: return true
        if (floePackages.isEmpty()) return true
        if (normalized == "/") return true
        if (normalized in setOf(
                "/data",
                "/data/data",
                "/data/user",
                "/data/user_de",
                "/data/media",
                "/storage",
                "/storage/emulated",
                "/storage/self",
                "/mnt",
                "/mnt/expand",
                "/mnt/user",
            )
        ) {
            return true
        }
        val segments = pathSegments(normalized)
        if (segments.size == 3 && segments[0] == "data" &&
            (segments[1] == "user" || segments[1] == "user_de") &&
            isUserSegment(segments[2])
        ) {
            return true
        }
        if (segments.size == 3 && segments[0] == "mnt" && segments[1] == "user" &&
            isUserSegment(segments[2])
        ) {
            return true
        }
        if (segments.size == 3 && segments[0] == "mnt" && segments[1] == "expand" &&
            isVolumeId(segments[2])
        ) {
            return true
        }
        if (segments.size == 4 && segments[0] == "mnt" && segments[1] == "expand" &&
            isVolumeId(segments[2]) &&
            (segments[3] == "user" || segments[3] == "user_de" ||
                segments[3] == "app" || segments[3] == "media")
        ) {
            return true
        }
        if (segments.size == 5 && segments[0] == "mnt" && segments[1] == "expand" &&
            isVolumeId(segments[2]) &&
            (segments[3] == "user" || segments[3] == "user_de") &&
            isUserSegment(segments[4])
        ) {
            return true
        }
        if (isExternalStorageRoot(normalized)) return true
        for (i in segments.indices) {
            if (segments[i] != "Android") continue
            val prefix = if (i == 0) "/" else "/" + segments.subList(0, i).joinToString("/")
            if (!isExternalStorageRoot(prefix)) continue
            if (i == segments.lastIndex) return true
            if (segments[i + 1] in ANDROID_APP_DIRS && i + 1 == segments.lastIndex) return true
        }
        return false
    }

    /** Platform trees that are readable for inspection but never writable here. */
    fun isReadOnlySystemPath(path: String): Boolean {
        val normalized = normalizeBase(path) ?: return false
        val first = pathSegments(normalized).firstOrNull()
        return first != null && first in SYSTEM_ROOT_NAMES
    }

    private fun isHardForbiddenPath(normalized: String): Boolean {
        for (prefix in HARD_FORBIDDEN_PREFIXES) {
            if (normalized == prefix || normalized.startsWith("$prefix/")) return true
        }
        return false
    }

    /** Parent directories that would grant every app, user or volume at once. */
    private fun isBroadParent(normalized: String): Boolean {
        if (normalized in setOf(
                "/data",
                "/data/data",
                "/data/user",
                "/data/user_de",
                "/data/local",
                "/data/media",
                "/storage",
                "/storage/emulated",
                "/storage/self",
                "/mnt",
                "/mnt/expand",
                "/mnt/user",
            )
        ) {
            return true
        }
        val segments = pathSegments(normalized)
        if (segments.size == 3 && segments[0] == "data" &&
            (segments[1] == "user" || segments[1] == "user_de") &&
            isUserSegment(segments[2])
        ) {
            return true
        }
        if (segments.size == 3 && segments[0] == "mnt" && segments[1] == "user" &&
            isUserSegment(segments[2])
        ) {
            return true
        }
        if (segments.size == 3 && segments[0] == "mnt" && segments[1] == "expand" &&
            isVolumeId(segments[2])
        ) {
            return true
        }
        if (segments.size == 4 && segments[0] == "mnt" && segments[1] == "expand" &&
            isVolumeId(segments[2]) &&
            (segments[3] == "user" || segments[3] == "user_de" ||
                segments[3] == "app" || segments[3] == "media")
        ) {
            return true
        }
        if (segments.size == 5 && segments[0] == "mnt" && segments[1] == "expand" &&
            isVolumeId(segments[2]) &&
            (segments[3] == "user" || segments[3] == "user_de") &&
            isUserSegment(segments[4])
        ) {
            return true
        }
        return false
    }

    private fun isSharedStorageScope(normalized: String): Boolean {
        val segments = pathSegments(normalized)
        if (normalized == "/sdcard" || normalized.startsWith("/sdcard/")) return true
        if (segments.size >= 3 && segments[0] == "storage" && segments[1] == "emulated" &&
            isUserSegment(segments[2])
        ) {
            return true
        }
        if (segments.size >= 3 && segments[0] == "storage" && segments[1] == "self" &&
            segments[2] == "primary"
        ) {
            return true
        }
        if (segments.size >= 4 && segments[0] == "mnt" && segments[1] == "user" &&
            isUserSegment(segments[2]) && segments[3] == "primary"
        ) {
            return true
        }
        if (segments.size >= 3 && segments[0] == "data" && segments[1] == "media" &&
            isUserSegment(segments[2])
        ) {
            return true
        }
        if (segments.size >= 2 && segments[0] == "storage" &&
            segments[1] !in setOf("emulated", "self") && isVolumeId(segments[1])
        ) {
            return true
        }
        if (segments.size >= 5 && segments[0] == "mnt" && segments[1] == "expand" &&
            isVolumeId(segments[2]) && segments[3] == "media" && isUserSegment(segments[4])
        ) {
            return true
        }
        return false
    }

    private fun isOtherAppDataScope(normalized: String, floePackages: Set<String>): Boolean {
        val segments = pathSegments(normalized)
        val pkg = when {
            segments.size >= 3 && segments[0] == "data" && segments[1] == "data" ->
                segments[2]
            segments.size >= 4 && segments[0] == "data" &&
                (segments[1] == "user" || segments[1] == "user_de") &&
                isUserSegment(segments[2]) -> segments[3]
            else -> return false
        }
        return isPackageSegment(pkg) && !FloePackageFamily.contains(pkg, floePackages)
    }

    private fun isAdoptedAppDataScope(normalized: String, floePackages: Set<String>): Boolean {
        val segments = pathSegments(normalized)
        val pkg = when {
            segments.size >= 6 && segments[0] == "mnt" && segments[1] == "expand" &&
                isVolumeId(segments[2]) &&
                (segments[3] == "user" || segments[3] == "user_de") &&
                isUserSegment(segments[4]) -> segments[5]
            segments.size >= 5 && segments[0] == "mnt" && segments[1] == "expand" &&
                isVolumeId(segments[2]) && segments[3] == "app" -> segments[4]
            else -> return false
        }
        return isPackageSegment(pkg) && !FloePackageFamily.contains(pkg, floePackages)
    }

    private fun isExternalStorageRoot(normalized: String): Boolean {
        val segments = pathSegments(normalized)
        return normalized == "/sdcard" ||
            normalized == "/storage/self/primary" ||
            (segments.size == 3 && segments[0] == "storage" && segments[1] == "emulated" &&
                isUserSegment(segments[2])) ||
            (segments.size == 4 && segments[0] == "mnt" && segments[1] == "user" &&
                isUserSegment(segments[2]) && segments[3] == "primary") ||
            (segments.size == 3 && segments[0] == "data" && segments[1] == "media" &&
                isUserSegment(segments[2])) ||
            (segments.size == 2 && segments[0] == "storage" &&
                segments[1] !in setOf("emulated", "self") && isVolumeId(segments[1])) ||
            (segments.size == 3 && segments[0] == "mnt" && segments[1] == "expand" &&
                isVolumeId(segments[2])) ||
            (segments.size == 5 && segments[0] == "mnt" && segments[1] == "expand" &&
                isVolumeId(segments[2]) && segments[3] == "media" &&
                isUserSegment(segments[4]))
    }

    private fun isFloePackage(packageName: String, floePackages: Set<String>): Boolean =
        FloePackageFamily.isWithinRoots(packageName, floePackages)

    private fun isUserSegment(segment: String): Boolean =
        segment.isNotEmpty() && segment.length <= 6 && segment.all { it in '0'..'9' }

    private fun isVolumeId(segment: String): Boolean =
        segment.isNotEmpty() && segment.length <= 128 &&
            segment[0].isLetterOrDigit() &&
            segment.all { it.isLetterOrDigit() || it == '_' || it == '.' || it == '-' }

    private fun isPackageSegment(segment: String): Boolean =
        segment.length in 1..255 &&
            segment[0].isLetter() &&
            segment.last() != '.' &&
            !segment.contains("..") &&
            segment.all { it.isLetterOrDigit() || it == '_' || it == '.' }

    private fun pathSegments(normalized: String): List<String> =
        if (normalized == "/") emptyList() else normalized.trim('/').split('/')

    private val HARD_FORBIDDEN_PREFIXES = listOf(
        "/proc",
        "/sys",
        "/dev",
        "/root",
        "/init",
        "/sbin",
        "/metadata",
        "/efs",
        "/persist",
        "/mnt/vendor",
        "/mnt/media_rw",
        "/data/system",
        "/data/misc",
        "/data/adb",
        "/data/apex",
        "/data/app",
        "/data/dalvik-cache",
        "/data/rollback",
        "/data/tombstones",
        "/data/vendor",
        "/data/security",
    )
}
