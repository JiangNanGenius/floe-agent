// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.pdf

import android.os.Parcel
import android.os.Parcelable

/**
 * Internal, launch-Intent-only request for the PDF preview screen. It is NOT
 * an authority token: the receiving Activity re-verifies EVERYTHING against
 * the real bytes inside the module-owned outputs root
 * ([OfficePdfReceiptPolicy.resolveOwnedOutput] + [OfficePdfReceiptPolicy.proveBytes])
 * before the isolated renderer ever sees a descriptor. A hand-crafted
 * request (this Activity is non-exported, so only this same app can build
 * one) still cannot open an arbitrary path: containment, op-name binding,
 * magic, exact length and whole-file SHA are re-proved at open time.
 */
@ConsistentCopyVisibility
data class OfficePdfPreviewRequest internal constructor(
    val canonicalPdfPath: String,
    val sha256: String,
    val lengthBytes: Long,
    val displayName: String,
    val opId: String,
    val generation: Long,
) : Parcelable {

    companion object {
        const val EXTRA_REQUEST = "com.floe.android.office.pdf.PREVIEW_REQUEST"

        fun of(
            snapshot: VerifiedPdfSnapshot,
            displayName: String,
        ): OfficePdfPreviewRequest {
            // snapshot.file is ALREADY the canonicalFile returned by
            // resolveOwnedOutput; `.path` avoids a second canonical-path IO
            // call on the caller (main) thread.
            return OfficePdfPreviewRequest(
                canonicalPdfPath = snapshot.file.path,
                sha256 = snapshot.sha256,
                lengthBytes = snapshot.lengthBytes,
                displayName = displayName,
                opId = snapshot.opId,
                generation = snapshot.generation,
            )
        }

        @JvmField
        val CREATOR = object : Parcelable.Creator<OfficePdfPreviewRequest> {
            override fun createFromParcel(source: Parcel): OfficePdfPreviewRequest {
                val path = source.readString().orEmpty()
                val sha = source.readString().orEmpty()
                val bytes = source.readLong()
                val name = source.readString().orEmpty()
                val opId = source.readString().orEmpty()
                val generation = source.readLong()
                return OfficePdfPreviewRequest(path, sha, bytes, name, opId, generation)
            }

            override fun newArray(size: Int): Array<OfficePdfPreviewRequest?> = arrayOfNulls(size)
        }
    }

    override fun describeContents(): Int = 0

    override fun writeToParcel(dest: Parcel, flags: Int) {
        dest.writeString(canonicalPdfPath)
        dest.writeString(sha256)
        dest.writeLong(lengthBytes)
        dest.writeString(displayName)
        dest.writeString(opId)
        dest.writeLong(generation)
    }
}
