// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.safgateway.SafCancelToken
import com.floe.android.safgateway.SafUriRef
import java.io.InputStream

/**
 * App-owned, verified Office output source for ONE Save Copy transfer.
 *
 * This is a SERVICE DEPENDENCY, not a file authorizer: the bytes described here
 * were produced and verified by the App (native private OUTPUT_READY staged into
 * an App-owned canonical path), and this class only carries the EXACT identity
 * facts plus a trusted bounded stream opener. The controller never invents,
 * re-derives or widens any of these facts; a mismatch fails the transfer
 * honestly instead of writing unchecked bytes (Main steering 2026-10-26:
 * workspace binary CAS and provider original writeback are separate later
 * outcomes — Save Copy writes ONLY the distinct document the system
 * CREATE_DOCUMENT flow returns).
 *
 * Construct through [OfficeSaveCopySource.create] only, after the App has
 * validated the native output receipt (fixed bytes/SHA/length, part-file +
 * rename staged path). Any future native receipt shape can be adapted by Main
 * into these plain facts without changing this class or the controller.
 */

/** Exact operation binding: one Office session, one App operation id, one per-save generation. */
data class OfficeSaveCopyIdentity(
    /** Exact Office session token the App bound the staged output to. A controller
     *  instance is bound for life to ONE session token; a new Office session uses
     *  a new controller, so a retired session can never prepare on another's. */
    val sessionToken: String,
    /** App-chosen opaque operation id (e.g. "save-copy"). Non-blank, never a path. */
    val operation: String,
    /** Strictly increasing PER-SAVE ordinal chosen by the App for this session.
     *  It is NOT the native document generation/version — native document state
     *  never flows into this field. Late/low per-save generations are STALE. */
    val generation: Long,
) {
    init {
        require(sessionToken.isNotBlank()) { "sessionToken must be the exact Office session binding" }
        require(operation.isNotBlank()) { "operation must be a non-blank App-chosen id" }
        require(generation > 0) { "generation must be a positive per-save ordinal" }
    }
}

/**
 * Optional identity of the document this output was edited FROM — never a target.
 * When [documentId] is known, the controller additionally refuses a picker result
 * whose backend-resolved document id equals it on the SAME provider authority
 * (alias refusal ordered before any grant persistence). This is a concrete
 * provider-scoped comparison — no cross-provider alias certainty and no
 * provider CAS is claimed; an unknown/unresolvable id falls back to the exact
 * URI-string rule only.
 */
data class OfficeSaveCopyOriginal(
    val uri: SafUriRef,
    val documentId: String? = null,
)

/**
 * Trusted stream over the App-staged verified bytes. The controller opens
 * exactly one stream per transfer attempt, reads it bounded (64 KiB chunks,
 * hard 256 MiB cap) and closes it before any grant reference or the source
 * lease is released. Implementations must return the SAME bytes on every call
 * for the life of the source; a stream that cannot honor [expectedSha256] /
 * [lengthBytes] fails the transfer, never adapts it.
 */
fun interface OfficeSaveCopyStreamOpener {
    fun open(cancel: SafCancelToken): InputStream
}

/**
 * App-held recoverability handle for the staged output bytes. The controller
 * closes it exactly once, only after ALL IO has settled, the grant references
 * are drained and its own state has published — never on caller-view
 * detachment, never mid-stream, never by a late retire while IO is in flight.
 * Closing releases ONLY the controller's BORROW: the independent caller
 * recovery owner keeps the retention obligation for the actual bytes, and
 * failed/cancelled output bytes stay recoverable under that owner's policy.
 * Implementations must make close idempotent.
 */
interface OfficeSaveCopyLease : AutoCloseable {
    override fun close()
}

class OfficeSaveCopySource private constructor(
    val identity: OfficeSaveCopyIdentity,
    /** Expected lowercase-hex SHA-256 of the exact output bytes. */
    val expectedSha256: String,
    /** Exact output byte count, 1..[MAX_BYTES]. */
    val lengthBytes: Long,
    /** Concrete document MIME offered to the CREATE_DOCUMENT picker. */
    val mimeType: String,
    /** Single safe display segment suggested as the destination file name. */
    val suggestedName: String,
    /** Original the output was edited from; a picker result equal to its exact URI
     *  (or, when a document id is known, equal id on the same provider authority) is refused. */
    val original: OfficeSaveCopyOriginal? = null,
    /** Optional App recoverability handle; closed exactly once by the controller only after settlement. */
    val lease: OfficeSaveCopyLease? = null,
    private val opener: OfficeSaveCopyStreamOpener,
) {

    companion object {
        /** Office input/output cap (Main decision 2026-10-26): 256 MiB, chunks 64 KiB. */
        const val MAX_BYTES: Long = 256L * 1024 * 1024

        private val SHA256_HEX = Regex("^[0-9a-f]{64}$")

        /**
         * Validate-and-construct. Throws IllegalArgumentException on any fact
         * the App should already have proven — the controller depends on these
         * being exact, so a bad source is a programming error, not a runtime
         * provider state.
         */
        fun create(
            identity: OfficeSaveCopyIdentity,
            expectedSha256: String,
            lengthBytes: Long,
            mimeType: String,
            suggestedName: String,
            original: OfficeSaveCopyOriginal? = null,
            lease: OfficeSaveCopyLease? = null,
            openStream: (SafCancelToken) -> InputStream,
        ): OfficeSaveCopySource {
            require(SHA256_HEX.matches(expectedSha256)) {
                "expectedSha256 must be 64 lowercase hex chars"
            }
            require(lengthBytes in 1..MAX_BYTES) {
                "lengthBytes must be 1..$MAX_BYTES (Office output cap)"
            }
            require(mimeType.isNotBlank() && !mimeType.any { it.isWhitespace() }) {
                "mimeType must be one concrete non-blank token"
            }
            // Concrete means concrete: ANY wildcard is refused, not just a
            // trailing "/*" suffix (Main review finding 7, 2026-10-26). "*/*",
            // "application/*", "*/doc" and empty/multi-slash shapes all fail.
            require('*' !in mimeType) {
                "mimeType must be a concrete document type (no wildcard characters)"
            }
            val slash = mimeType.indexOf('/')
            require(
                slash > 0 && slash < mimeType.length - 1 && mimeType.indexOf('/', slash + 1) < 0,
            ) {
                "mimeType must be exactly one non-empty type/subtype pair"
            }
            require(!isUnsafeDisplaySegment(suggestedName)) {
                "suggestedName must be a single safe display segment"
            }
            return OfficeSaveCopySource(
                identity = identity,
                expectedSha256 = expectedSha256,
                lengthBytes = lengthBytes,
                mimeType = mimeType,
                suggestedName = suggestedName,
                original = original,
                lease = lease,
                opener = OfficeSaveCopyStreamOpener(openStream),
            )
        }

        /**
         * Mirrors the gateway's safe-segment rule (SafStagingNames) so a bad
         * name is refused here instead of inside pickerForCreateDocument.
         */
        internal fun isUnsafeDisplaySegment(name: String): Boolean =
            name.isBlank() || name.contains('/') || name.contains('\\') ||
                name == "." || name == ".." || name.any { it.code < 0x20 || it.code == 0x7f }
    }

    /** Controller-only: open the trusted bounded byte stream for one pass. */
    internal fun openBytes(cancel: SafCancelToken): InputStream = opener.open(cancel)
}
