// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officerecovery

import java.io.File
import java.nio.charset.StandardCharsets
import java.util.Locale
import org.json.JSONArray
import org.json.JSONObject

/**
 * C08 owned-content enumeration for the explicit full-backup channel.
 *
 * This class READS the existing durable recovery journal and re-measures each
 * referenced artifact through [OfficeRecoveryArtifacts]. It never mutates the
 * journal, never flushes/terminates an active Office session, never follows a
 * path outside the App-owned roots and never copies by itself: the trusted
 * Swift domain performs the exact rooted stream after re-validating the same
 * fixed root shape.
 *
 * What travels OVER THE IN-PROCESS BRIDGE is content plus bounded descriptive
 * metadata and the fixed-root-relative path needed for the exact rooted copy.
 * The old candidate id, task/workspace/run/root/native-generation/session
 * identities, destination URI, live grants and pending actions are NEVER
 * stored in the package.
 */
internal data class OfficeDraftCaptureRecord(
    val root: Root,
    val relativePath: String,
    val kind: Kind,
    val displayName: String,
    val format: String,
    val bytes: Long,
    val sha256: String,
    val createdAtMillis: Long,
    val updatedAtMillis: Long,
) {
    internal enum class Root { WORKING, OUTPUTS, RESTORED }

    internal enum class Kind { WORKING_COPY, VERIFIED_OUTPUT }
}

internal data class OfficeDraftCaptureOmission(
    val reason: String,
    val bytes: Long?,
    val sha256: String?,
)

internal data class OfficeDraftCapture(
    val records: List<OfficeDraftCaptureRecord>,
    val omissions: List<OfficeDraftCaptureOmission>,
    val deduplicated: Int,
) {
    val isEmpty: Boolean get() = records.isEmpty()

    /**
     * Bounded wire shape for `c07.backup.begin.officeDrafts`. Fixed root
     * names keep app-private absolute paths off the channel; the Swift domain
     * derives the three fixed roots from its accepted runtime root.
     */
    fun toJson(): JSONObject {
        val recordArray = JSONArray()
        for (record in records.take(MAX_RECORDS)) {
            recordArray.put(JSONObject().apply {
                put("root", when (record.root) {
                    OfficeDraftCaptureRecord.Root.WORKING -> "working"
                    OfficeDraftCaptureRecord.Root.OUTPUTS -> "outputs"
                    OfficeDraftCaptureRecord.Root.RESTORED -> "restored"
                })
                put("relativePath", record.relativePath)
                put("kind", when (record.kind) {
                    OfficeDraftCaptureRecord.Kind.WORKING_COPY -> "workingCopy"
                    OfficeDraftCaptureRecord.Kind.VERIFIED_OUTPUT -> "verifiedOutput"
                })
                put("displayName", boundedDisplayName(record.displayName))
                put("format", record.format)
                put("bytes", record.bytes)
                put("sha256", record.sha256)
                put("createdAtMillis", record.createdAtMillis)
                put("updatedAtMillis", record.updatedAtMillis)
            })
        }
        val omissionArray = JSONArray()
        for (omission in omissions.take(MAX_OMISSIONS)) {
            omissionArray.put(JSONObject().apply {
                put("reason", omission.reason)
                omission.bytes?.let { put("bytes", it) }
                omission.sha256?.let { put("sha256", it) }
            })
        }
        return JSONObject().apply {
            put("format", FORMAT)
            put("records", recordArray)
            put("omissions", omissionArray)
            put("deduplicated", deduplicated)
        }
    }

    internal companion object {
        const val FORMAT = "floe.office-drafts/1"
        const val MAX_RECORDS = 64
        const val MAX_OMISSIONS = 128
    }
}

/** One bounded user-facing name; never a local path or control text. */
internal fun boundedDisplayName(raw: String): String {
    val sanitized = raw
        .substringAfterLast('/')
        .substringAfterLast('\\')
        .filter { it.code >= 0x20 && it.code != 0x7f }
        .trim()
        .trimStart('.')
        .ifBlank { "Office document" }
    val builder = StringBuilder(minOf(sanitized.length, 120))
    for (character in sanitized) {
        val candidate = builder.toString() + character
        if (candidate.toByteArray(StandardCharsets.UTF_8).size > 240) break
        builder.append(character)
    }
    return builder.toString().ifBlank { "Office document" }
}

internal class OfficeRecoveryDraftCatalog(
    private val journal: OfficeRecoveryJournal,
    private val artifacts: OfficeRecoveryArtifacts,
    /** Explicit App-owned restored-document root; production derives it from
     * the ONE Office preview owner. */
    private val restoredRoot: File? = null,
) {
    private companion object {
        val SHA256_HEX = Regex("^[0-9a-f]{64}$")
    }

    fun capture(): OfficeDraftCapture {
        val records = ArrayList<OfficeDraftCaptureRecord>(16)
        val omissions = ArrayList<OfficeDraftCaptureOmission>(4)
        // Dedupe happens in the trusted Swift copy only AFTER the exact bytes
        // were verified. Sending both candidates here preserves a working-copy
        // fallback if a verified export changes between inspection and copy.
        val deduplicated = 0
        val workingRoot = runCatching { artifacts.workingRootDirectory.canonicalFile }.getOrNull()
        val outputsRoot = runCatching { artifacts.outputsRootDirectory.canonicalFile }.getOrNull()
        val candidates = runCatching { journal.snapshot() }.getOrDefault(emptyList())
            .sortedBy { it.id }

        for (candidate in candidates) {
            if (records.size >= OfficeDraftCapture.MAX_RECORDS) {
                omissions += OfficeDraftCaptureOmission("unreadable", null, null)
                break
            }
            val format = candidate.format.lowercase(Locale.ROOT)
            if (format !in OFFICE_RECOVERY_FORMATS) continue

            // Verified export first: identical working bytes are deduplicated
            // in favour of the stronger module-verified provenance.
            if (candidate.hasVerifiedOutput) {
                val output = artifacts.inspectOutput(candidate)
                val outputFormat = candidate.outputFormat?.lowercase(Locale.ROOT)
                val path = candidate.outputPath
                val sha = output.sha256
                if (output.state == OfficeRecoveryFileState.AVAILABLE &&
                    outputFormat != null && outputFormat in OFFICE_RECOVERY_FORMATS &&
                    path != null && sha != null && SHA256_HEX.matches(sha) &&
                    output.bytes in 1L..MAX_OFFICE_RECOVERY_BYTES
                ) {
                    val relative = relativeUnder(outputsRoot, path, maxDepth = 2)
                    if (relative == null || outputsRoot == null) {
                        omissions += OfficeDraftCaptureOmission(
                            "untrusted", output.bytes, sha)
                    } else {
                        records += OfficeDraftCaptureRecord(
                            root = OfficeDraftCaptureRecord.Root.OUTPUTS,
                            relativePath = relative,
                            kind = OfficeDraftCaptureRecord.Kind.VERIFIED_OUTPUT,
                            displayName = boundedDisplayName(candidate.displayName),
                            format = outputFormat,
                            bytes = output.bytes,
                            sha256 = sha,
                            createdAtMillis = candidate.createdAtMillis,
                            updatedAtMillis = maxOf(
                                candidate.createdAtMillis,
                                candidate.updatedAtMillis,
                            ),
                        )
                    }
                } else {
                    omissions += OfficeDraftCaptureOmission(
                        omissionReason(output.state), output.bytes, sha)
                }
            }

            // Mutable working copy. Missing/corrupt bytes are explicit
            // counted omissions; a live editor is never flushed or closed.
            val working = artifacts.inspectWorkingCopy(candidate)
            val workingSha = working.sha256
            if (working.state == OfficeRecoveryFileState.AVAILABLE &&
                workingSha != null && SHA256_HEX.matches(workingSha) &&
                working.bytes in 1L..MAX_OFFICE_RECOVERY_BYTES
            ) {
                val relative = relativeUnder(
                    workingRoot, candidate.workingCopyPath, maxDepth = 2)
                if (relative == null || workingRoot == null) {
                    omissions += OfficeDraftCaptureOmission(
                        "untrusted", working.bytes, workingSha)
                } else {
                    records += OfficeDraftCaptureRecord(
                        root = OfficeDraftCaptureRecord.Root.WORKING,
                        relativePath = relative,
                        kind = OfficeDraftCaptureRecord.Kind.WORKING_COPY,
                        displayName = boundedDisplayName(candidate.displayName),
                        format = format,
                        bytes = working.bytes,
                        sha256 = workingSha,
                        createdAtMillis = candidate.createdAtMillis,
                        updatedAtMillis = maxOf(
                            candidate.createdAtMillis,
                            candidate.updatedAtMillis,
                        ),
                    )
                }
            } else {
                omissions += OfficeDraftCaptureOmission(
                    omissionReason(working.state), working.bytes, workingSha)
            }
        }
        // Fresh restored Office documents are also persisted user content.
        // Carrying them again prevents a later full backup from silently
        // dropping what an earlier restore created.
        val restoredDirectory = restoredRoot
            ?: workingRoot?.parentFile?.let { File(it, "restored") }
        if (restoredDirectory != null && restoredDirectory.isDirectory) {
            val store = OfficeRestoredDocumentStore(restoredDirectory)
            for (document in store.list()) {
                if (records.size >= OfficeDraftCapture.MAX_RECORDS) {
                    omissions += OfficeDraftCaptureOmission("unreadable", null, null)
                    break
                }
                if (store.verifiedFile(document) == null) {
                    omissions += OfficeDraftCaptureOmission(
                        "unreadable", document.byteCount, document.sha256)
                    continue
                }
                val now = System.currentTimeMillis()
                records += OfficeDraftCaptureRecord(
                    root = OfficeDraftCaptureRecord.Root.RESTORED,
                    relativePath = "${document.restoreID}/${document.fileName}",
                    kind = when (document.kind) {
                        OfficeRestoredDocument.Kind.WORKING_COPY ->
                            OfficeDraftCaptureRecord.Kind.WORKING_COPY
                        OfficeRestoredDocument.Kind.VERIFIED_OUTPUT ->
                            OfficeDraftCaptureRecord.Kind.VERIFIED_OUTPUT
                    },
                    displayName = boundedDisplayName(document.displayName),
                    format = document.format,
                    bytes = document.byteCount,
                    sha256 = document.sha256,
                    createdAtMillis = now,
                    updatedAtMillis = now,
                )
            }
        }
        return OfficeDraftCapture(
            records = records,
            omissions = omissions.take(OfficeDraftCapture.MAX_OMISSIONS),
            deduplicated = deduplicated,
        )
    }

    private fun relativeUnder(
        root: File?,
        rawPath: String,
        maxDepth: Int,
    ): String? {
        if (root == null || rawPath.isEmpty() || rawPath.length > 4096) return null
        val canonical = runCatching { File(rawPath).canonicalFile }.getOrNull() ?: return null
        val rootPath = root.path
        if (!canonical.path.startsWith(rootPath + File.separator)) return null
        val relative = canonical.path.substring(rootPath.length + 1)
            .replace(File.separatorChar, '/')
        if (relative.isEmpty() || relative.startsWith("/") || relative.contains("..")) {
            return null
        }
        val parts = relative.split('/')
        if (parts.isEmpty() || parts.size > maxDepth) return null
        if (parts.any { it.isEmpty() || it == "." || it == ".." }) return null
        return relative
    }


    private fun omissionReason(state: OfficeRecoveryFileState): String = when (state) {
        OfficeRecoveryFileState.MISSING -> "missing"
        OfficeRecoveryFileState.CORRUPT -> "corrupt"
        OfficeRecoveryFileState.UNTRUSTED -> "untrusted"
        OfficeRecoveryFileState.AVAILABLE -> "unreadable"
    }
}

/**
 * Process-local handoff from the ONE live Office preview/recovery owner to
 * the C07 data-exchange controller. It references the existing journal and
 * artifact authority; it never constructs a second journal, database or
 * backup engine. Cleared naturally on process death.
 */
internal object OfficeRecoveryDraftRegistry : OfficeDraftCaptureSource {
    @Volatile
    private var catalog: OfficeRecoveryDraftCatalog? = null

    @Volatile
    private var restoredOpenPort: OfficeRestoredDocumentOpenPort? = null

    fun install(
        catalog: OfficeRecoveryDraftCatalog?,
        restoredOpenPort: OfficeRestoredDocumentOpenPort?,
    ) {
        this.catalog = catalog
        this.restoredOpenPort = restoredOpenPort
    }

    fun clear(catalog: OfficeRecoveryDraftCatalog) {
        if (this.catalog === catalog) this.catalog = null
    }

    override fun capture(): OfficeDraftCapture? = catalog?.capture()

    fun openPort(): OfficeRestoredDocumentOpenPort? = restoredOpenPort
}

/** The only surface the data-exchange controller needs for backup capture. */
internal fun interface OfficeDraftCaptureSource {
    fun capture(): OfficeDraftCapture?
}
