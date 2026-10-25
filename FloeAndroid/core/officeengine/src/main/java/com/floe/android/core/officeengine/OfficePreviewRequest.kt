package com.floe.android.core.officeengine

import android.os.Parcel
import android.os.Parcelable
import java.util.Locale

/**
 * Formats the R1 viewer accepts: exactly the three offline preview formats
 * whose actual App rendering is this round's goal (Main review 2026-10-26:
 * public acceptance stays within the actually verified three-format scope;
 * other engine-readable types remain future, separately verified work).
 *
 * The allowlist is a FORMAT boundary, not macro suppression: a DOCX
 * container can still carry active payloads (renamed or embedded), so an
 * extension check is honestly not a security control. Kernel-level macro
 * auto-execution and external-reference auto-update policy of the pinned
 * engine is reported as an unresolved device-verification item, not claimed.
 */
enum class OfficeDocumentFormat(val fileExtension: String, val mime: String) {
    DOCX("docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document"),
    XLSX("xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
    PPTX("pptx", "application/vnd.openxmlformats-officedocument.presentationml.presentation"),
}

/** R1 authority is READ_ONLY. EDIT is a reserved seam, refused until R2 exists. */
enum class OfficePermission { READ_ONLY, EDIT }

/**
 * Trusted, App-staged open request.
 *
 * Field contract (Main 2026-10-26):
 *  - [stagedFilePath] is a canonical absolute path inside the application's
 *    own data area, produced by the App-side stager (the workspace snapshot
 *    stager or a direct SAF acceptance staging). It is NOT a content URI,
 *    provider grant or picker path; the module never resolves URIs and never
 *    grants anything.
 *  - [sha256] + [lengthBytes] describe the staged snapshot the host verified;
 *    the engine process re-verifies both (and the received shape, see
 *    [OfficeEngineService] unmarshal revalidation) before native work
 *    (fail-closed).
 *  - Session identity fields are real optional context, never invented:
 *    workspace-less local preview (direct SAF pick, no Linux/model
 *    configured) passes them as null and the viewer works unchanged.
 *  - [sessionToken] is an opaque host-owned value identifying this exact
 *    native mount/generation; every callback is fenced by it.
 *
 * Construct through [OfficePreviewRequest.of], which runs the pure
 * [OfficeRequestPolicy] checks eagerly so App callers fail at the call site,
 * long before an Activity starts.
 */
@ConsistentCopyVisibility
data class OfficePreviewRequest internal constructor(
    val sessionToken: String,
    val stagedFilePath: String,
    val format: OfficeDocumentFormat,
    val sha256: String,
    val lengthBytes: Long,
    val displayName: String,
    val languageTag: String?,
    val permission: OfficePermission,
    val ownerTaskId: String?,
    val workspaceId: String?,
    val nativeEpoch: String?,
    val hostGeneration: String?,
    val sourceLogicalPath: String?,
    val sourceId: String?,
    val sourceRevision: String?,
) : Parcelable {

    init {
        require(permission == OfficePermission.READ_ONLY) {
            "G05-R1 viewer authority is READ_ONLY; EDIT is reserved for R2"
        }
    }

    /**
     * Server-side revalidation after unmarshalling: shape rules again, and
     * [OfficeRequestPolicy.formatForPath] must independently reproduce the
     * stated [format] (a mismatched parcel is refused fail-closed, never
     * trusted).
     */
    internal fun revalidated(): Result<OfficePreviewRequest> {
        OfficeRequestPolicy.validateShape(
            sessionToken = sessionToken,
            stagedFilePath = stagedFilePath,
            sha256 = sha256,
            lengthBytes = lengthBytes,
            displayName = displayName,
            permission = permission,
        )?.let { return Result.failure(it) }
        if (OfficeRequestPolicy.formatForPath(stagedFilePath) != format) {
            return Result.failure(
                OfficeException(
                    OfficeFailureCode.UNSUPPORTED_FORMAT,
                    "parcelled request disagrees with its staged extension",
                ),
            )
        }
        return Result.success(this)
    }

    companion object {
        /**
         * Validating factory. [format] is inferred from the staged file name;
         * only the three R1 formats are accepted.
         */
        fun of(
            sessionToken: String,
            stagedFilePath: String,
            sha256: String,
            lengthBytes: Long,
            displayName: String,
            languageTag: String? = null,
            permission: OfficePermission = OfficePermission.READ_ONLY,
            ownerTaskId: String? = null,
            workspaceId: String? = null,
            nativeEpoch: String? = null,
            hostGeneration: String? = null,
            sourceLogicalPath: String? = null,
            sourceId: String? = null,
            sourceRevision: String? = null,
        ): Result<OfficePreviewRequest> {
            val failure = OfficeRequestPolicy.validateShape(
                sessionToken = sessionToken,
                stagedFilePath = stagedFilePath,
                sha256 = sha256,
                lengthBytes = lengthBytes,
                displayName = displayName,
                permission = permission,
            )
            if (failure != null) return Result.failure(failure)
            val format = OfficeRequestPolicy.formatForPath(stagedFilePath)
                ?: return Result.failure(
                    OfficeException(OfficeFailureCode.UNSUPPORTED_FORMAT, "staged file is not an R1 preview format"),
                )
            return Result.success(
                OfficePreviewRequest(
                    sessionToken = sessionToken,
                    stagedFilePath = stagedFilePath,
                    format = format,
                    sha256 = sha256,
                    lengthBytes = lengthBytes,
                    displayName = displayName,
                    languageTag = languageTag,
                    permission = permission,
                    ownerTaskId = ownerTaskId,
                    workspaceId = workspaceId,
                    nativeEpoch = nativeEpoch,
                    hostGeneration = hostGeneration,
                    sourceLogicalPath = sourceLogicalPath,
                    sourceId = sourceId,
                    sourceRevision = sourceRevision,
                ),
            )
        }

        // Android requires a PUBLIC static CREATOR field for unmarshalling
        // (parcelable convention; @JvmField on the companion val provides it).
        // Parcel field order MUST match writeToParcel exactly, below.
        @JvmField
        val CREATOR = object : Parcelable.Creator<OfficePreviewRequest> {
            override fun createFromParcel(source: Parcel): OfficePreviewRequest {
                val sessionToken = source.readString().orEmpty()
                val stagedFilePath = source.readString().orEmpty()
                val format = OfficeDocumentFormat.valueOf(source.readString() ?: "")
                val sha256 = source.readString().orEmpty()
                val lengthBytes = source.readLong()
                val displayName = source.readString().orEmpty()
                val languageTag = source.readString()
                val permission = OfficePermission.valueOf(source.readString() ?: "")
                val ownerTaskId = source.readString()
                val workspaceId = source.readString()
                val nativeEpoch = source.readString()
                val hostGeneration = source.readString()
                val sourceLogicalPath = source.readString()
                val sourceId = source.readString()
                val sourceRevision = source.readString()
                return OfficePreviewRequest(
                    sessionToken = sessionToken,
                    stagedFilePath = stagedFilePath,
                    format = format,
                    sha256 = sha256,
                    lengthBytes = lengthBytes,
                    displayName = displayName,
                    languageTag = languageTag,
                    permission = permission,
                    ownerTaskId = ownerTaskId,
                    workspaceId = workspaceId,
                    nativeEpoch = nativeEpoch,
                    hostGeneration = hostGeneration,
                    sourceLogicalPath = sourceLogicalPath,
                    sourceId = sourceId,
                    sourceRevision = sourceRevision,
                )
            }

            override fun newArray(size: Int): Array<OfficePreviewRequest?> = arrayOfNulls(size)
        }
    }

    override fun describeContents(): Int = 0

    override fun writeToParcel(dest: Parcel, flags: Int) {
        dest.writeString(sessionToken)
        dest.writeString(stagedFilePath)
        dest.writeString(format.name)
        dest.writeString(sha256)
        dest.writeLong(lengthBytes)
        dest.writeString(displayName)
        dest.writeString(languageTag)
        dest.writeString(permission.name)
        dest.writeString(ownerTaskId)
        dest.writeString(workspaceId)
        dest.writeString(nativeEpoch)
        dest.writeString(hostGeneration)
        dest.writeString(sourceLogicalPath)
        dest.writeString(sourceId)
        dest.writeString(sourceRevision)
    }
}
