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
     *
     * R2: EDIT is an accepted explicit host request. Shape rules are the same
     * for both permissions; the additional EDIT fact — the staged file must
     * be a WRITABLE working copy (never a read-only R1 snapshot) — needs the
     * real File and is enforced fail-closed in the engine open pipeline.
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
        permission != OfficePermission.READ_ONLY && permission != OfficePermission.EDIT ->
            OfficeException(OfficeFailureCode.ROUTE_UNAVAILABLE, "unknown permission")
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

    // ------------------------------------------------------------------
    // R2: save/export shape rules and real output verification
    // ------------------------------------------------------------------

    /**
     * Export format tokens accepted by [OfficeSaveOperation.STAGED_EXPORT].
     * Mirrors the pinned producer's own save-as formats (upstream
     * LOActivity.java REQUEST_SAVEAS_* / getFormatForRequestCode) narrowed to
     * this stage's scope: the three OOXML container formats, their ODF
     * equivalents and PDF. The token doubles as the output file extension —
     * the pinned LOKit saveAs derives the export filter from the target URL
     * extension (upstream creates the temp file as "." + format), so the
     * module ALWAYS writes the staged output with this exact extension.
     */
    val EXPORT_FORMATS: Set<String> = setOf("docx", "xlsx", "pptx", "odt", "ods", "odp", "pdf")

    private val ZIP_CONTAINER_FORMATS: Set<String> = setOf("docx", "xlsx", "pptx", "odt", "ods", "odp")

    private val OP_ID_REGEX = Regex("^[A-Za-z0-9_-]{1,64}$")

    /** Real leading bytes expected for a verified export output. */
    fun expectedMagic(format: String): ByteArray =
        if (format == "pdf") "%PDF-".toByteArray(Charsets.US_ASCII)
        else byteArrayOf(0x50, 0x4B, 0x03, 0x04) // ZIP local file header (OOXML + ODF)

    /**
     * Pure shape validation for one host save/export operation. Returns null
     * when valid; otherwise the fail-closed exception. Cross-process
     * submissions are re-validated through this same function on the engine
     * side (never trusted from the parcel).
     */
    fun validateSaveRequestShape(
        opId: String,
        sessionToken: String,
        generation: Long,
        operation: OfficeSaveOperation,
        format: String?,
        options: String?,
        suggestedName: String?,
    ): OfficeException? = when {
        !OP_ID_REGEX.matches(opId) ->
            OfficeException(OfficeFailureCode.INTERNAL, "opId must be 1..64 chars of [A-Za-z0-9_-]")
        sessionToken.isBlank() || sessionToken.length > 256 ->
            OfficeException(OfficeFailureCode.INTERNAL, "sessionToken must be 1..256 chars")
        generation < 1L ->
            OfficeException(OfficeFailureCode.INTERNAL, "generation must be positive")
        operation == OfficeSaveOperation.STAGED_EXPORT &&
            (format == null || format.lowercase(Locale.ROOT) !in EXPORT_FORMATS) ->
            OfficeException(OfficeFailureCode.UNSUPPORTED_FORMAT, "export format outside the pinned allowlist")
        operation == OfficeSaveOperation.WORKING_COPY_FLUSH && format != null ->
            OfficeException(OfficeFailureCode.INTERNAL, "flush operations carry no format")
        options != null && (options.length > OfficeSaveRequest.MAX_OPTIONS_CHARS ||
            options.any { it.code < 0x20 || it == '\u007f' } ||
            options.contains("TakeOwnership")) ->
            // Inert passthrough, but never an ownership transfer: the loaded
            // document identity must not move (upstream uses TakeOwnership
            // only for its own copy-switch flow, which this module never does).
            OfficeException(OfficeFailureCode.INTERNAL, "options must be inert and bounded")
        suggestedName != null && (suggestedName.isBlank() || suggestedName.length > 240 ||
            suggestedName.contains('/') || suggestedName.contains('\\') ||
            suggestedName.contains('\u0000') || suggestedName.contains('|')) ->
            OfficeException(OfficeFailureCode.INTERNAL, "suggestedName must be an inert label")
        else -> null
    }

    /** Result of the real post-write output verification (never a void-success). */
    data class OutputVerification(
        val failure: OfficeSaveFailureCode?,
        val sha256: String?,
        val bytes: Long,
    ) {
        val verified: Boolean get() = failure == null
    }

    /**
     * Verifies one staged export output AFTER the synchronous JNI saveAs
     * returned: regular file, non-empty, within the module byte cap, format
     * magic present, and a full bounded read producing the receipt digest.
     * Any failure names the exact honest reason; the failed partial file is
     * the CALLER's to remove (only files this op attempt created).
     */
    fun verifyStagedOutput(file: File, format: String): OutputVerification {
        if (!file.exists() || !file.isFile) {
            return OutputVerification(OfficeSaveFailureCode.OUTPUT_MISSING, null, 0L)
        }
        val length = file.length()
        if (length <= 0L) {
            return OutputVerification(OfficeSaveFailureCode.OUTPUT_EMPTY, null, 0L)
        }
        if (length > MAX_STAGED_BYTES) {
            return OutputVerification(OfficeSaveFailureCode.OUTPUT_TOO_LARGE, null, length)
        }
        val magic = expectedMagic(format)
        return try {
            val md = java.security.MessageDigest.getInstance("SHA-256")
            var magicOk = true
            var magicPos = 0
            var total = 0L
            file.inputStream().buffered().use { input ->
                val buffer = ByteArray(1 shl 16)
                while (true) {
                    val read = input.read(buffer)
                    if (read <= 0) break
                    total += read
                    if (total > MAX_STAGED_BYTES) {
                        return OutputVerification(OfficeSaveFailureCode.OUTPUT_TOO_LARGE, null, total)
                    }
                    for (i in 0 until read) {
                        if (magicPos < magic.size) {
                            if (buffer[i] != magic[magicPos]) magicOk = false
                            magicPos++
                        } else break
                    }
                    md.update(buffer, 0, read)
                }
            }
            if (magicPos < magic.size || !magicOk) {
                return OutputVerification(OfficeSaveFailureCode.OUTPUT_TYPE_MISMATCH, null, total)
            }
            OutputVerification(null, md.digest().joinToString("") { "%02x".format(it) }, total)
        } catch (e: Exception) {
            OutputVerification(OfficeSaveFailureCode.OUTPUT_UNREADABLE, null, length)
        }
    }

    /**
     * Whole-file digest re-read used as the WORKING_COPY_FLUSH byte proof
     * after a native success ack. Returns null when the working copy is not
     * a readable regular file anymore (the receipt then honestly fails with
     * ACK_WITHOUT_VERIFIABLE_BYTES instead of claiming a flush).
     */
    fun digestWorkingCopy(file: File): Pair<String, Long>? {
        if (!file.isFile) return null
        return try {
            val md = java.security.MessageDigest.getInstance("SHA-256")
            var total = 0L
            file.inputStream().buffered().use { input ->
                val buffer = ByteArray(1 shl 20)
                while (true) {
                    val read = input.read(buffer)
                    if (read <= 0) break
                    total += read
                    md.update(buffer, 0, read)
                }
            }
            md.digest().joinToString("") { "%02x".format(it) } to total
        } catch (e: Exception) {
            null
        }
    }
}
