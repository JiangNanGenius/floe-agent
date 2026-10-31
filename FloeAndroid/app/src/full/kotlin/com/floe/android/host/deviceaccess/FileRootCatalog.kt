// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import android.os.Environment
import com.floe.android.R
import com.floe.android.rootsystem.policy.FloePackageFamily
import java.io.File
import java.security.MessageDigest

/**
 * The file scopes the USER may explicitly grant to the Android system
 * service. Three groups, each with a different truth:
 *
 *  - shared public storage subdirectories (the original six choices);
 *  - read-only platform trees (`/system`, `/vendor`, `/product`,
 *    `/system_ext`, `/odm`, `/apex`). They are inspection-only even when the
 *    global write ceiling is on; the backend refuses writable grants and
 *    writes at the canonical target;
 *  - explicit other-app data folders typed by the user while Root is active.
 *    Only the current Android user's CE/DE/adopted package folder and its
 *    subfolders are accepted here; a package name is never guessed from model
 *    text, there is no all-apps or `/data` choice, and the App never tries to
 *    canonicalize/list the path with its own UID. The root service resolves it
 *    and reports real OS/SELinux/unlock failures.
 *
 * There is no free-form all-files scope and no absolute-path tool argument:
 * tool calls only name one of these deterministic ids. Floe's own package and
 * kernel/security/raw-device trees are denied again by the backend and are
 * never offered here.
 */
internal object FileRootCatalog {

    /**
     * Deterministic read-only base used for host diagnostics when the user has
     * not selected any file folder. It is part of the configured ceiling but
     * never a selectable file grant unless the user picks the System root.
     */
    const val DIAGNOSTICS_BASE = "/system"
    const val DIAGNOSTICS_ID = "system"
    const val MAX_APP_DATA_ROOTS = 8

    private const val APP_DATA_ID_PREFIX = "appdata:"
    /**
     * Stable Floe identity family, resolved by the single backend policy
     * (`FloePackageFamily`). The parent App id is `com.floe.agent.full[.dev]`;
     * the runtime component is the SIBLING `com.floe.agent.runtime.full[.dev]`,
     * not a child of the parent, so an ancestor/descendant check alone would
     * offer the runtime's private data.
     */
    private const val MAX_APP_DATA_PATH = 900
    private const val MAX_APP_DATA_SUBPATH = 512
    private const val MAX_APP_DATA_SEGMENTS = 32

    private val PACKAGE_NAME = Regex("^[A-Za-z0-9_]+(\\.[A-Za-z0-9_]+)+$")

    enum class Kind { SHARED, SYSTEM, APP_DATA }

    data class Root(
        val id: String,
        val labelRes: Int,
        val label: String,
        val path: String,
        val kind: Kind,
        val writable: Boolean,
    ) {
        val readOnly: Boolean get() = !writable
    }

    /**
     * Shared public storage folders. A missing/unmounted folder is simply not
     * offered (there is nothing to grant); it never prevents the system
     * controller, ADB pairing or Root from starting.
     */
    fun sharedRoots(): List<Root> {
        if (Environment.getExternalStorageState() != Environment.MEDIA_MOUNTED) {
            return emptyList()
        }
        val candidates = listOf(
            Triple("downloads", R.string.device_access_root_downloads, Environment.DIRECTORY_DOWNLOADS),
            Triple("documents", R.string.device_access_root_documents, Environment.DIRECTORY_DOCUMENTS),
            Triple("pictures", R.string.device_access_root_pictures, Environment.DIRECTORY_PICTURES),
            Triple("dcim", R.string.device_access_root_dcim, Environment.DIRECTORY_DCIM),
            Triple("music", R.string.device_access_root_music, Environment.DIRECTORY_MUSIC),
            Triple("movies", R.string.device_access_root_movies, Environment.DIRECTORY_MOVIES),
        )
        val result = ArrayList<Root>(candidates.size)
        for ((id, label, directory) in candidates) {
            val file = try {
                @Suppress("DEPRECATION")
                Environment.getExternalStoragePublicDirectory(directory)
            } catch (_: Throwable) {
                null
            } ?: continue
            val canonical = try {
                file.canonicalFile
            } catch (_: Throwable) {
                continue
            }
            if (!canonical.isDirectory) continue
            val guard = canonical.path
            if (guard.startsWith("/data") || guard.startsWith("/system")) continue
            result += Root(
                id = id,
                labelRes = label,
                label = "",
                path = guard,
                kind = Kind.SHARED,
                writable = true,
            )
        }
        return result
    }

    /**
     * Platform inspection trees. Deterministic names; the backend resolves the
     * real path and refuses writes/remounts. Never writable through this App.
     */
    fun systemRoots(): List<Root> = listOf(
        systemRoot("system", R.string.device_access_root_system, "/system"),
        systemRoot("vendor", R.string.device_access_root_vendor, "/vendor"),
        systemRoot("product", R.string.device_access_root_product, "/product"),
        systemRoot("system_ext", R.string.device_access_root_system_ext, "/system_ext"),
        systemRoot("odm", R.string.device_access_root_odm, "/odm"),
        systemRoot("apex", R.string.device_access_root_apex, "/apex"),
    )

    private fun systemRoot(id: String, labelRes: Int, path: String): Root = Root(
        id = id,
        labelRes = labelRes,
        label = "",
        path = path,
        kind = Kind.SYSTEM,
        writable = false,
    )

    /** Shared + system roots; available even when no public folder exists. */
    fun standardRoots(): List<Root> = sharedRoots() + systemRoots()

    /**
     * Parses one explicit other-app data folder. Pure and deterministic: no
     * filesystem access, canonicalization or listing happens with the App UID.
     * Returns the normalized absolute base or null when the path is not a
     * current-user other-app CE/DE/adopted package folder.
     */
    fun normalizeAppDataBase(raw: String, ownPackage: String, userId: Int): String? {
        val trimmed = raw.trim()
        if (trimmed.length !in 2..MAX_APP_DATA_PATH) return null
        if (!trimmed.startsWith("/")) return null
        if (trimmed.any { it == '\u0000' || it.isISOControl() || it == '\\' }) return null
        val segments = trimmed.split('/').filter { it.isNotEmpty() }
        if (segments.size < 3 || segments.size > MAX_APP_DATA_SEGMENTS) return null
        if (segments.any { it == "." || it == ".." || it.length > 255 }) return null
        if (userId !in 0..999) return null

        val packageIndex = when {
            segments.size >= 4 && segments[0] == "data" &&
                (segments[1] == "user" || segments[1] == "user_de") &&
                segments[2].isDigits() && segments[2].toIntOrNull() == userId -> 3

            segments.size >= 3 && segments[0] == "data" && segments[1] == "data" &&
                userId == 0 -> 2

            segments.size >= 6 && segments[0] == "mnt" && segments[1] == "expand" &&
                isVolumeSegment(segments[2]) &&
                (segments[3] == "user" || segments[3] == "user_de") &&
                segments[4].isDigits() && segments[4].toIntOrNull() == userId -> 5

            segments.size >= 5 && segments[0] == "mnt" && segments[1] == "expand" &&
                isVolumeSegment(segments[2]) && segments[3] == "app" -> 4

            else -> return null
        }
        val packageName = segments[packageIndex]
        if (!PACKAGE_NAME.matches(packageName) || packageName.length > 200) return null
        if (isFloePackage(packageName, ownPackage)) return null
        val subPath = segments.drop(packageIndex + 1).joinToString("/")
        if (subPath.length > MAX_APP_DATA_SUBPATH) return null
        // Normalize the numeric user segment so "0" and "00" are one folder.
        val normalized = segments.toMutableList()
        when {
            normalized[0] == "data" &&
                (normalized[1] == "user" || normalized[1] == "user_de") ->
                normalized[2] = userId.toString()
            normalized[0] == "mnt" && normalized[1] == "expand" &&
                (normalized[3] == "user" || normalized[3] == "user_de") ->
                normalized[4] = userId.toString()
        }
        return "/" + normalized.joinToString("/")
    }

    /**
     * Builds one explicit app-data root. Deterministic id: the same normalized
     * folder always maps to the same id, and different folders cannot collide.
     */
    fun appDataRoot(raw: String, ownPackage: String, userId: Int): Root? {
        val path = normalizeAppDataBase(raw, ownPackage, userId) ?: return null
        return Root(
            id = appDataId(path),
            labelRes = 0,
            label = path,
            path = path,
            kind = Kind.APP_DATA,
            writable = true,
        )
    }

    fun appDataId(normalizedPath: String): String =
        APP_DATA_ID_PREFIX + sha256Hex(normalizedPath).take(16)

    fun isAppDataId(id: String): Boolean = id.startsWith(APP_DATA_ID_PREFIX)

    fun find(id: String, roots: List<Root> = standardRoots()): Root? =
        roots.firstOrNull { it.id == id }

    private fun isFloePackage(packageName: String, ownPackage: String): Boolean {
        if (FloePackageFamily.contains(packageName, setOf(ownPackage))) return true
        // Also refuse an ancestor of the supplied actual own package
        // (defense in depth for a differently branded build).
        return ownPackage.isNotEmpty() && ownPackage.startsWith("$packageName.")
    }

    private fun isVolumeSegment(segment: String): Boolean =
        segment.isNotEmpty() && segment.length <= 128 &&
            segment[0].isLetterOrDigit() &&
            segment.all { it.isLetterOrDigit() || it == '_' || it == '.' || it == '-' }

    private fun String.isDigits(): Boolean = isNotEmpty() && all { it in '0'..'9' }

    private fun sha256Hex(value: String): String {
        val bytes = MessageDigest.getInstance("SHA-256")
            .digest(value.toByteArray(Charsets.UTF_8))
        return bytes.joinToString("") { "%02x".format(it) }
    }
}
