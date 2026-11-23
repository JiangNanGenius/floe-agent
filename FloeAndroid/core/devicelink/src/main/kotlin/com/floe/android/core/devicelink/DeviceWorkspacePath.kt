// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.devicelink

import java.text.Normalizer
import java.util.Locale

/** Shared wire names. Filesystem containment and local aliases are checked by the host. */
object DeviceWorkspacePath {
    const val CONFLICT_DIRECTORY = "Floe Sync Conflicts"
    private val blockedNames = setOf(
        ".git", ".svn", ".hg", ".ds_store", "node_modules", ".venv", "__pycache__",
        ".build", ".gradle", ".swiftpm", ".floe", "floe sync conflicts",
        ".ssh", ".aws", ".gnupg", ".netrc", ".npmrc", ".pypirc", ".git-credentials", ".htpasswd",
    )
    private val blockedPrefixes = listOf(
        ".floe-", ".env", ".pgpass", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519",
    )
    private val blockedExtensions = setOf("pem", "key", "keystore", "p12", "pfx", "jks")

    fun collisionKey(path: String): String? {
        if (path.isEmpty() || path.startsWith('~') ||
            path.any { it == '\\' || it == ':' || it.code < 32 || it.code == 127 }) return null
        val bytes = path.encodeToByteArray()
        if (bytes.size > 1_024 || bytes.decodeToString() != path) return null
        val parts = path.split('/')
        if (parts.size > 64 || parts.any { it.isEmpty() || it == "." || it == ".." || it.encodeToByteArray().size > 255 }) {
            return null
        }
        val canonical = parts.map(::canonicalName)
        if (canonical.first() in setOf("mounts", "network") || canonical.any(::isBlocked)) return null
        return canonical.joinToString("/")
    }

    /** The spelling comparison used for collation on the receiving filesystem too. */
    fun canonicalName(name: String): String =
        Normalizer.normalize(name, Normalizer.Form.NFC).lowercase(Locale.ROOT)

    fun directoryConflictDigest(path: String): String = DeviceWorkspaceManifest.digest(path.encodeToByteArray())

    private fun isBlocked(name: String): Boolean =
        name in blockedNames || blockedPrefixes.any(name::startsWith) ||
            name.substringAfterLast('.', "") in blockedExtensions
}
