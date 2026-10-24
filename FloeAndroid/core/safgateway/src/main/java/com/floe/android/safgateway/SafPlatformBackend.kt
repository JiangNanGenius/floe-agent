// SPDX-License-Identifier: MPL-2.0
package com.floe.android.safgateway

/**
 * The ONLY seam where ContentResolver / DocumentsContract is touched.
 *
 * [AndroidSafBackend] is the real device implementation. JVM unit tests inject
 * fakes — the Android framework stubs (which throw on every method) are never
 * pretended to be functional. Every method runs on the caller's IO worker
 * context, must honor [SafCancelToken], and reports exceptional provider
 * states as [SafBackendFaultException] instead of Android exception types.
 *
 * Identity rule: implementations must return EXACT URI strings and provider
 * document ids; they must never rewrite, re-encode or resolve them to paths.
 */
interface SafPlatformBackend {

    /** Classify via platform DocumentsContract (tree vs document vs neither). */
    fun classifyUri(uriString: String): SafUriKind

    /** OS truth: `ContentResolver.persistedUriPermissions` snapshot. */
    fun persistedGrants(): List<GrantSnapshot>

    /**
     * Persist EXACTLY ONE flag. Implementations must check-then-take per flag
     * (the platform requires the flag to be actually granted to us and offers
     * persistence only for READ/WRITE individually).
     */
    fun takePersistable(uri: SafUriRef, flag: SafAccessFlag): TakeOutcome

    /** Release one flag; returns true only when the platform call succeeded. */
    fun releasePersistable(uri: SafUriRef, flag: SafAccessFlag): Boolean

    /** Tree URI -> root document ref built with buildDocumentUriUsingTree (exact strings). */
    fun resolveTreeRoot(tree: SafUriRef): SafDocumentRef?

    /**
     * Exact canonical child URI for (tree, documentId), built with
     * buildDocumentUriUsingTree. Core never assembles URI strings itself;
     * null when the platform rejects the combination.
     */
    fun documentUriFor(tree: SafUriRef, documentId: String): SafUriRef?

    /**
     * Truthful live access probe for one anchor URI: persisted rows from the
     * OS PLUS the real current-session permission (`checkUriPermission` with
     * own pid/uid on Android; actual descriptor open remains the final word
     * for UNKNOWN). A persisted-only denial must never erase a still-live
     * session grant (Main steering 2026-10-24; AttachmentStagingService
     * pickedWithReadGrant fallback precedent).
     */
    fun probeAccess(uri: SafUriRef, needsRead: Boolean, needsWrite: Boolean): AccessProbe

    /**
     * Bounded child scan over a HELD, opaque, bounded-lifetime provider cursor
     * (Main steering 2026-10-24: providers may ignore SORT/LIMIT and names may
     * repeat, so displayName cursors are forbidden — they would drop or
     * duplicate same-name rows). `cursorToken == null` starts a fresh scan;
     * a returned token continues the held one. Expiry must be reported
     * truthfully in `note`, never silently re-read as if continued.
     */
    fun queryChildDocuments(
        tree: SafUriRef,
        parentDocumentId: String?,
        limit: Int,
        cursorToken: String?,
        cancel: SafCancelToken,
    ): ChildScan

    /** Explicitly release one held cursor lease (returns true when a lease existed). */
    fun releaseCursor(cursorToken: String): Boolean

    /** Release every held cursor (service shutdown; leases also expire on their own). */
    fun releaseAllCursors()

    /** Single-document metadata via DocumentsContract.queryDocument; null = not found. */
    fun queryDocument(ref: SafDocumentRef, cancel: SafCancelToken): SafDocument?

    /** Real tree membership via isChildDocument or the provider canonical path on API 28. */
    fun isChildOf(child: SafDocumentRef, ancestorTree: SafUriRef, cancel: SafCancelToken): Boolean

    /**
     * Open a bounded read stream. `mimeFilter` non-null requests a typed
     * (converted) representation for virtual documents. `lengthHintBytes`
     * comes from the descriptor and may be null (unknown — never coerced).
     */
    fun openRead(ref: SafDocumentRef, mimeFilter: String?, cancel: SafCancelToken): ReadOpen

    /**
     * Open `openOutputStream(uri, "wt")`. `UnsupportedMode` when the provider
     * refuses truncate-write semantics; callers must then use a non-destructive
     * path or report honestly. No atomicity is implied by this mode.
     */
    fun openWriteTruncate(ref: SafDocumentRef, cancel: SafCancelToken): WriteOpen

    /** Provider-declared alternative stream types for virtual documents (empty when none). */
    fun streamTypes(ref: SafDocumentRef): List<String>

    fun createDocument(
        tree: SafUriRef,
        parentDocumentId: String?,
        mimeType: String,
        displayName: String,
        cancel: SafCancelToken,
    ): OpResult<SafDocumentRef>

    fun renameDocument(ref: SafDocumentRef, newName: String, cancel: SafCancelToken): OpResult<SafDocumentRef>

    fun moveDocument(
        ref: SafDocumentRef,
        destTree: SafUriRef,
        destParentDocumentId: String?,
        cancel: SafCancelToken,
    ): OpResult<SafDocumentRef>

    fun copyDocument(
        ref: SafDocumentRef,
        destTree: SafUriRef,
        destParentDocumentId: String?,
        cancel: SafCancelToken,
    ): OpResult<SafDocumentRef>

    fun deleteDocument(ref: SafDocumentRef, cancel: SafCancelToken): OpResult<Boolean>

    /** Diagnostics for Main qualification: reported parity problems of the documented bit copies. */
    fun selfCheck(): List<String>
}

sealed class ReadOpen {
    data class Opened(val input: java.io.InputStream, val lengthHintBytes: Long?) : ReadOpen()
    /** Document identity is valid but the provider reports it as gone. */
    data object NotFound : ReadOpen()
}

sealed class WriteOpen {
    data class Opened(val output: java.io.OutputStream) : WriteOpen()
    /** Provider rejects "wt"; destructive replace is NOT available on this document. */
    data object UnsupportedMode : WriteOpen()
    data object NotFound : WriteOpen()
}

/**
 * Mutation result with EXACT returned identity. `NullReturned` mirrors the
 * documented DocumentsContract behavior (providers return null on failure);
 * exceptional states arrive as [SafBackendFaultException].
 */
sealed class OpResult<out T> {
    data class Ok<T>(val value: T) : OpResult<T>()
    data class NullReturned(val detail: String) : OpResult<Nothing>()
}
