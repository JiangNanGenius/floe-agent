package com.floe.android.core.officeengine

import java.io.File
import java.util.Locale

/**
 * Pure, JVM-testable validation boundary.
 *
 * The engine process consumes ONLY trusted internal staged snapshots: the
 * file must resolve (canonical) inside one of the application's own data
 * roots, must match the digest metadata the host stager recorded, and its
 * extension must be one of the three R1 preview formats. Display names are
 * inert labels (never joined into paths). No caller input here can grant
 * permissions or widen reach.
 *
 * Honesty boundary (Main review 2026-10-26): the extension allowlist is a
 * FORMAT scope, NOT macro suppression. Containers can still carry active
 * payloads; the pinned engine kernel's auto-execution / external-update
 * behaviour is reported as an unresolved device-verification item and is not
 * claimed safe by this policy.
 */
object OfficeRequestPolicy {

    private val SHA256_REGEX = Regex("^[0-9a-f]{64}$")

    /**
     * Shape checks that need no filesystem access. Returns null when valid,
     * otherwise a fail-closed [OfficeException].
     */
    fun validateShape(
        sessionToken: String,
        stagedFilePath: String,
        sha256: String,
        lengthBytes: Long,
        displayName: String,
        permission: OfficePermission,
    ): OfficeException? = when {
        sessionToken.isBlank() || sessionToken.length > 256 ->
            OfficeException(OfficeFailureCode.UNSUPPORTED_FORMAT, "sessionToken must be 1..256 chars")
        stagedFilePath.isBlank() || !stagedFilePath.startsWith("/") ->
            OfficeException(OfficeFailureCode.STAGED_FILE_MISSING, "stagedFilePath must be absolute")
        !SHA256_REGEX.matches(sha256) ->
            OfficeException(OfficeFailureCode.STAGED_FILE_MISMATCH, "sha256 must be 64 lowercase hex chars")
        lengthBytes <= 0L || lengthBytes > MAX_STAGED_BYTES ->
            OfficeException(OfficeFailureCode.STAGED_FILE_MISMATCH, "staged size must be 1..$MAX_STAGED_BYTES bytes")
        displayName.isBlank() || displayName.length > 240 || displayName.contains('/') ||
            displayName.contains('\\') || displayName.contains('\u0000') ->
            OfficeException(OfficeFailureCode.UNSUPPORTED_FORMAT, "displayName must be an inert label")
        permission != OfficePermission.READ_ONLY ->
            OfficeException(OfficeFailureCode.ROUTE_UNAVAILABLE, "R1 viewer authority is READ_ONLY")
        else -> null
    }

    const val MAX_STAGED_BYTES: Long = 256L shl 20 // 256 MiB ceiling for R1 snapshots

    /** Extension-based format detection inside the three-format R1 scope. */
    fun formatForPath(path: String): OfficeDocumentFormat? {
        val name = path.substringAfterLast('/').lowercase(Locale.ROOT)
        val ext = name.substringAfterLast('.', "")
        return OfficeDocumentFormat.entries.firstOrNull { it.fileExtension == ext }
    }

    /**
     * Canonical containment inside App-owned roots. [rootPaths] come from the
     * running Context (dataDir/filesDir/cacheDir/noBackupFilesDir), never from
     * caller input; the staged path must canonicalise to a real regular file
     * under one of them. Returns null + exception outcome pair style.
     */
    fun resolveStagedFile(appRootPaths: List<String>, stagedFilePath: String): Pair<File?, OfficeException?> {
        val file = File(stagedFilePath)
        val canonical = try {
            file.canonicalPath
        } catch (e: Exception) {
            return null to OfficeException(OfficeFailureCode.STAGED_FILE_MISSING, "path cannot be canonicalised")
        }
        val roots = appRootPaths.map { r -> runCatching { File(r).canonicalPath }.getOrDefault(r) }
        val contained = roots.any { root ->
            canonical == root || canonical.startsWith(root.removeSuffix("/") + "/")
        }
        if (!contained) {
            return null to OfficeException(
                OfficeFailureCode.STAGED_FILE_MISSING,
                "staged file escapes the application data area",
            )
        }
        if (!file.isFile) {
            return null to OfficeException(
                OfficeFailureCode.STAGED_FILE_MISSING,
                "staged file is not a regular file",
            )
        }
        if (file.canonicalFile != file.absoluteFile) {
            // Symlinked: reject; the stager writes plain regular files.
            return null to OfficeException(
                OfficeFailureCode.STAGED_FILE_MISMATCH,
                "staged file path must be canonical (no symlinks)",
            )
        }
        return file to null
    }

    /** True only when the file exists, is regular and matches size + digest. */
    fun verifyStagedDigest(file: File, expectedBytes: Long, expectedSha256: String): Boolean {
        if (!file.isFile || file.length() != expectedBytes) return false
        val digest = try {
            val md = java.security.MessageDigest.getInstance("SHA-256")
            file.inputStream().buffered().use { input ->
                val buffer = ByteArray(1 shl 20)
                while (true) {
                    val read = input.read(buffer)
                    if (read <= 0) break
                    md.update(buffer, 0, read)
                }
            }
            md.digest().joinToString("") { "%02x".format(it) }
        } catch (e: Exception) {
            return false
        }
        return digest == expectedSha256
    }

    /**
     * file:// URL handed to the engine (upstream parity: the document URL is
     * derived from the verified canonical staged path only).
     */
    fun engineLoadUrl(canonicalStagedPath: String): String = "file://" + canonicalStagedPath
}
