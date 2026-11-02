// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officerecovery

import com.floe.android.core.officeengine.OfficeRequestPolicy
import com.floe.android.core.officeengine.OfficeSaveFailureCode
import java.io.File
import java.nio.file.Files
import java.util.Locale
import java.util.UUID

/**
 * Ownership and byte facts for recovery artifacts. This is the ONLY place
 * that decides whether a journal path names an App-owned file that a recovery
 * action may read or delete.
 *
 * Rules (all re-checked against the live filesystem, never against journal
 * text alone):
 *  - a working copy is exactly <workingRoot>/<uuid>/document.<docx|xlsx|pptx>;
 *  - a verified output is exactly
 *    <outputsRoot>/<nativeGeneration>/<opId>-<elapsed>.<format>;
 *  - both are canonical, non-symlink regular files inside the App-owned root;
 *  - a working copy is MUTABLE, so a digest different from the journal base is
 *    expected (the engine may have written it) and is reported as changed —
 *    it is corruption only when the file is missing/unreadable/not the
 *    declared OOXML/PDF shape;
 *  - a verified output is IMMUTABLE: its digest and length must match the
 *    recorded module receipt exactly, or it is corrupt;
 *  - deletion never follows a symlink, never touches a path outside the
 *    roots, and never deletes a user destination (destination URIs are not
 *    files in this App's storage).
 */
internal class OfficeRecoveryArtifacts(
    workingRoot: File,
    outputsRoot: File,
) {
    private val workingRoot: File = runCatching { workingRoot.canonicalFile }.getOrNull() ?: workingRoot
    private val outputsRoot: File = runCatching { outputsRoot.canonicalFile }.getOrNull() ?: outputsRoot

    /** Exact owned roots (already canonicalized) for the C08 backup adapter. */
    internal val workingRootDirectory: File get() = workingRoot
    internal val outputsRootDirectory: File get() = outputsRoot

    private companion object {
        val OP_ID = Regex("^[A-Za-z0-9_-]{1,64}$")
        val SHA256_HEX = Regex("^[0-9a-f]{64}$")
        val EDIT_EXTENSIONS = setOf("docx", "xlsx", "pptx")
    }

    data class WorkingFacts(
        val state: OfficeRecoveryFileState,
        val sha256: String? = null,
        val bytes: Long = 0L,
        val changedSinceBase: Boolean = false,
    )

    data class OutputFacts(
        val state: OfficeRecoveryFileState,
        val sha256: String? = null,
        val bytes: Long = 0L,
    )

    /**
     * Inspect the working copy exactly at its canonical owned location. The
     * file is never created, truncated, read through a symlink or moved.
     */
    fun inspectWorkingCopy(candidate: OfficeRecoveryCandidate): WorkingFacts {
        val path = candidate.workingCopyPath
        val format = candidate.format.lowercase(Locale.ROOT)
        if (format !in EDIT_EXTENSIONS || !isOwnedWorkingPath(path, format)) {
            return WorkingFacts(OfficeRecoveryFileState.UNTRUSTED)
        }
        val file = File(path)
        if (!file.exists()) return WorkingFacts(OfficeRecoveryFileState.MISSING)
        if (Files.isSymbolicLink(file.toPath()) || !file.isFile) {
            return WorkingFacts(OfficeRecoveryFileState.UNTRUSTED)
        }
        val verification = runCatching { OfficeRequestPolicy.verifyStagedOutput(file, format) }
            .getOrElse { return WorkingFacts(OfficeRecoveryFileState.CORRUPT) }
        if (!verification.verified) {
            return WorkingFacts(
                if (verification.failure == OfficeSaveFailureCode.OUTPUT_MISSING) {
                    OfficeRecoveryFileState.MISSING
                } else {
                    OfficeRecoveryFileState.CORRUPT
                },
            )
        }
        val sha = verification.sha256 ?: return WorkingFacts(OfficeRecoveryFileState.CORRUPT)
        if (!SHA256_HEX.matches(sha) || verification.bytes !in 1..MAX_OFFICE_RECOVERY_BYTES) {
            return WorkingFacts(OfficeRecoveryFileState.CORRUPT)
        }
        return WorkingFacts(
            state = OfficeRecoveryFileState.AVAILABLE,
            sha256 = sha,
            bytes = verification.bytes,
            changedSinceBase = sha != candidate.workingCopyBaseSha256 ||
                verification.bytes != candidate.workingCopyBaseBytes,
        )
    }

    /**
     * Inspect the exact module-verified output. The recorded digest/length are
     * a requirement, not a hint: any drift marks the bytes corrupt and the
     * export action refuses until the user re-verifies through Office.
     */
    fun inspectOutput(candidate: OfficeRecoveryCandidate): OutputFacts {
        val path = candidate.outputPath ?: return OutputFacts(OfficeRecoveryFileState.MISSING)
        val sha = candidate.outputSha256 ?: return OutputFacts(OfficeRecoveryFileState.UNTRUSTED)
        val format = candidate.outputFormat?.lowercase(Locale.ROOT) ?: return OutputFacts(OfficeRecoveryFileState.UNTRUSTED)
        val opId = candidate.outputOpId ?: return OutputFacts(OfficeRecoveryFileState.UNTRUSTED)
        val generation = candidate.outputNativeGeneration
        if (!SHA256_HEX.matches(sha) || candidate.outputBytes !in 1..MAX_OFFICE_RECOVERY_BYTES ||
            format !in OFFICE_RECOVERY_FORMATS ||
            !isOwnedOutputPath(path, generation, opId, format)
        ) {
            return OutputFacts(OfficeRecoveryFileState.UNTRUSTED)
        }
        val file = File(path)
        if (!file.exists()) return OutputFacts(OfficeRecoveryFileState.MISSING)
        if (Files.isSymbolicLink(file.toPath()) || !file.isFile) {
            return OutputFacts(OfficeRecoveryFileState.UNTRUSTED)
        }
        val verification = runCatching { OfficeRequestPolicy.verifyStagedOutput(file, format) }
            .getOrElse { return OutputFacts(OfficeRecoveryFileState.CORRUPT) }
        if (!verification.verified) {
            return OutputFacts(
                if (verification.failure == OfficeSaveFailureCode.OUTPUT_MISSING) {
                    OfficeRecoveryFileState.MISSING
                } else {
                    OfficeRecoveryFileState.CORRUPT
                },
            )
        }
        if (verification.bytes != candidate.outputBytes || verification.sha256 != sha) {
            return OutputFacts(OfficeRecoveryFileState.CORRUPT, verification.sha256, verification.bytes)
        }
        return OutputFacts(OfficeRecoveryFileState.AVAILABLE, verification.sha256, verification.bytes)
    }

    /** True when [path] names the exact owned working-copy shape for [format]. */
    fun isOwnedWorkingPath(path: String, format: String): Boolean {
        if (path.isEmpty() || path.length > 4096 || path.contains('\u0000') || !File(path).isAbsolute) return false
        val file = runCatching { File(path).canonicalFile }.getOrNull() ?: return false
        val root = workingRoot
        val parent = file.parentFile ?: return false
        val session = parent.name
        if (runCatching { UUID.fromString(session) }.isFailure) return false
        return parent.parentFile?.path == root.path &&
            file.name == "document.${format.lowercase(Locale.ROOT)}" &&
            file.path.startsWith(root.path + File.separator)
    }

    /** True when [path] names the exact owned verified-output shape. */
    fun isOwnedOutputPath(path: String, generation: Long, opId: String, format: String): Boolean {
        if (path.isEmpty() || path.length > 4096 || path.contains('\u0000') || !File(path).isAbsolute) return false
        if (generation < 1L || !OP_ID.matches(opId) || format.lowercase(Locale.ROOT) !in OFFICE_RECOVERY_FORMATS) {
            return false
        }
        val file = runCatching { File(path).canonicalFile }.getOrNull() ?: return false
        val root = outputsRoot
        val parent = file.parentFile ?: return false
        if (parent.name != generation.toString() || parent.parentFile?.path != root.path) return false
        if (!file.path.startsWith(root.path + File.separator)) return false
        return file.name.matches(
            Regex("^" + Regex.escape(opId) + "-[0-9]+\\." + Regex.escape(format.lowercase(Locale.ROOT)) + "$"),
        )
    }

    /**
     * Delete ONLY owned retained artifacts. Returns false when an owned file
     * existed but could not be removed (the journal record must be preserved
     * so the user can retry). Untrusted paths are not touched and are not an
     * error: they are simply not this App's data.
     */
    fun deleteOwned(candidate: OfficeRecoveryCandidate): Boolean {
        var clean = true
        val format = candidate.format.lowercase(Locale.ROOT)
        if (format in EDIT_EXTENSIONS && isOwnedWorkingPath(candidate.workingCopyPath, format)) {
            clean = deleteFileAndEmptyParent(File(candidate.workingCopyPath)) && clean
        }
        val outputPath = candidate.outputPath
        val outputFormat = candidate.outputFormat?.lowercase(Locale.ROOT)
        val outputOpId = candidate.outputOpId
        if (outputPath != null && outputFormat != null && outputOpId != null &&
            isOwnedOutputPath(outputPath, candidate.outputNativeGeneration, outputOpId, outputFormat)
        ) {
            clean = deleteFileAndEmptyParent(File(outputPath)) && clean
        }
        return clean
    }

    private fun deleteFileAndEmptyParent(file: File): Boolean {
        return try {
            if (Files.isSymbolicLink(file.toPath())) return false
            if (file.exists() && !file.delete()) return false
            val parent = file.parentFile
            if (parent != null && parent.exists() && parent.list()?.isEmpty() == true) {
                // Only the attempt's own directory; a non-empty directory is
                // left intact (another output/working copy still uses it).
                parent.delete()
            }
            true
        } catch (_: RuntimeException) {
            false
        }
    }
}
